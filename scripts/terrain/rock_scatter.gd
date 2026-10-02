## Rock scattering: talus boulders, glacial erratics and scree, plus the keep-out test
## shared with tree scattering.
##
## Split out of terrain_gen.gd (2026-09-25). Static-only: never instantiated; call as
## RockScatter.some_func(...). WorldGenerator (terrain_gen.gd) runs the pipeline.
class_name RockScatter
extends RefCounted

## -- Cliff-face boulder scattering --
## Placed along each cliff feature's low-side foot, using the exact same
## fault-line data _add_cliff_features already computes (center,
## orientation, half-length, step_height) rather than re-deriving anything
## from the final heightmap -- real talus/rockfall accumulates specifically
## at the base of a cliff, not scattered uniformly across open ground.
## Uses Boulder01 (mesh id 1 in terrain_assets.tres -- see
## tools/setup_rock_assets.gd).
const BOULDER_MESH_ID := 1
const BOULDER_MIN_PER_FEATURE := 1
const BOULDER_MAX_PER_FEATURE := 6 ## before length scaling -- see _scatter_boulders (bumped 3->6: a real talus fan is denser than a token rock or two)
const BOULDER_PER_FEATURE_LENGTH_DIVISOR := 5.0 ## roughly 1 boulder per this many world units of cliff length (bumped from 8: longer cliff faces should earn meaningfully more talus, since more cliff = more rockfall)
const BOULDER_FOOT_MARGIN_MIN := 1.0 ## units past the face's own edge softness before the nearest boulder can sit
const BOULDER_FOOT_MARGIN_MAX := 4.0
const BOULDER_LATERAL_JITTER := 2.0 ## random scatter off the fault line itself, so boulders don't read as a ruler-straight row
const BOULDER_SCALE_MIN := 0.7
const BOULDER_SCALE_MAX := 1.4
const BOULDER_EMBED_DEPTH := 0.05 ## sinks the boulder slightly into the ground so its (non-zero) mesh-space base never floats visibly above the terrain -- kept small since Boulder01's own origin already sits close to its base (see boulder_01_1k's AABB)
const BOULDER_FOOT_MARGIN_STEP_BACK := 2.5 ## extra distance added per retry when the first-choice spot is too steep -- see _scatter_boulders
const BOULDER_MAX_PLACEMENT_ATTEMPTS := 4
const BOULDER_MAX_SLOPE_NORMAL_Y := 0.85 ## reject (and retry farther out) any spot steeper than this normal.y -- keeps boulders off the cliff face itself, not just past its nominal edge
const BOULDER_SCENE_PATH := "res://assets/models/rocks/boulder_01/boulder_01_2k.glb" ## source mesh for the runtime-built collision shape (its LOD0 mesh's simplified convex hull) -- see _scatter_boulders. 2026-09-24: was the 1k glb, now the same 2k glb the boulder renders with (1k deleted)
const BOULDER_COLLIDER_CONTAINER_NAME := "BoulderColliders" ## sibling Node3D (under the same parent as this generator/the live Terrain3D) that holds one StaticBody3D+CollisionShape3D per scattered boulder, rebuilt fresh every run

## Extra rock meshes (stone_01/rock_07/rock_09), added purely for scatter
## variety -- registered as Terrain3DMeshAsset ids 2/3/4 in
## terrain_assets.tres by setup_rock_assets.gd, alongside Boulder01's
## existing id 1. ROCK_MESH_IDS is the pool every talus/erratic placement
## below now picks ONE id from at random (uniform) instead of always using
## BOULDER_MESH_ID -- see _scatter_boulders.
## 2026-09-30: + batch 2, namaqualand_boulder_02..06 (ids 33-37, same setup tool).
const ROCK_MESH_IDS: Array[int] = [BOULDER_MESH_ID, 2, 3, 4, 33, 34, 35, 36, 37]
const ROCK_SCENE_PATHS := {
	1: BOULDER_SCENE_PATH,
	2: "res://assets/models/rocks/stone_01/stone_01_2k.glb",
	3: "res://assets/models/rocks/rock_07/rock_07_2k.glb",
	4: "res://assets/models/rocks/rock_09/rock_09_2k.glb",
	33: "res://assets/models/rocks/namaqualand_boulder_02/namaqualand_boulder_02_2k.glb",
	34: "res://assets/models/rocks/namaqualand_boulder_03/namaqualand_boulder_03_2k.glb",
	35: "res://assets/models/rocks/namaqualand_boulder_04/namaqualand_boulder_04_2k.glb",
	36: "res://assets/models/rocks/namaqualand_boulder_05/namaqualand_boulder_05_2k.glb",
	37: "res://assets/models/rocks/namaqualand_boulder_06/namaqualand_boulder_06_2k.glb",
}
## Poly Haven's boulder_01 was modeled/exported at genuine boulder scale
## (LOD0 mesh AABB ~1.83 units on its longest axis). stone_01/rock_07/
## rock_09 turned out to be modeled at a much smaller real-world scale
## (longest-axis AABB 0.15/0.32/0.14 units respectively -- checked via
## debug_print_mesh_sizes in setup_rock_assets.gd), which is what made them
## render "very very tiny" next to Boulder01. FIXED AT IMPORT TIME instead
## of here: each rock's .glb.import now sets nodes/root_scale (6.81/3.12/
## 6.91) with nodes/apply_root_scale=true, baking the size fix directly
## into the imported mesh geometry (now ~1.0 unit on its longest axis for
## all three, a bit smaller than Boulder01's ~1.83 so it still reads as the
## standout large rock) -- confirmed via debug_print_mesh_sizes. A prior
## version of this file applied the same normalization again here, as an
## extra per-instance scale multiplier -- that's gone now that the meshes
## themselves are the right size, since keeping both would double-scale.
## ROCK_BASE_SCALE stays at 1.0 for every id so BOULDER_SCALE_MIN/MAX's
## existing random roll (see _scatter_boulders) is the only scale variation
## applied at scatter time, same as Boulder01 always had.
const ROCK_BASE_SCALE := {
	1: 1.0,
	2: 1.0,
	3: 1.0,
	4: 1.0,
	33: 1.0,
	34: 1.0,
	35: 1.0,
	36: 1.0,
	37: 1.0,
}

## -- Scree layer scattering (2026-09-21) --
## A dense, collider-free debris carpet at the SAME cliff feet the boulder
## pass reads, layered UNDER the boulders as the correlated finer tier the
## terrain field notes call for (gravel + fist-sized chips vs the sparser
## ~1 m boulders). Reuses _scatter_boulders' exact masks -- cliff features,
## cliff/outcrop keep-outs, road weight, slope normal -- but with its own much
## higher density, tighter foot band, gentler slope tolerance, a gravel/fist
## sub-pool split, and NO per-instance collision (scree is cosmetic; the
## terrain collider already carries the ground). See _scatter_scree.
## Meshes registered by setup_scree_assets.gd as Terrain3DMeshAsset ids 5-13:
##   fist tier   = namaqualand_rocks_01  a-d -> ids 5-8   (0.20-0.23 m)
##   gravel tier = namaqualand_stones_01 a-e -> ids 9-13  (0.04-0.15 m)
const SCREE_FIST_MESH_IDS: Array[int] = [5, 6, 7, 8]
const SCREE_GRAVEL_MESH_IDS: Array[int] = [9, 10, 11, 12, 13]
const SCREE_MESH_IDS: Array[int] = [5, 6, 7, 8, 9, 10, 11, 12, 13]
const SCREE_GRAVEL_FRACTION := 0.72 ## share drawn from the small gravel pool; the rest are the larger chips. Real talus is mostly fine debris with a scatter of bigger blocks.
const SCREE_MIN_PER_FEATURE := 12
const SCREE_MAX_PER_FEATURE := 260 ## before length/step scaling -- a dense carpet, not a token few (contrast BOULDER_MAX_PER_FEATURE = 6)
const SCREE_PER_FEATURE_LENGTH_DIVISOR := 0.6 ## ~1.7 scree per world unit of cliff length before step scaling
const SCREE_FOOT_MARGIN_MIN := 0.0 ## scree banks right against the foot edge (vs boulders' 1.0 standoff)
const SCREE_FOOT_MARGIN_MAX := 3.0 ## and thins out by here -- a tighter band than the boulder talus (max 4.0)
const SCREE_LATERAL_JITTER := 1.2
const SCREE_END_INSET_FRACTION := 0.05 ## scree reaches closer to the cliff tips than boulders (0.15)
const SCREE_SCALE_MIN := 0.6
const SCREE_SCALE_MAX := 1.5
const SCREE_TALUS_DENSITY_EXPONENT := 2.6 ## even stronger near-face pile-up than boulders (2.2) -- a scree cone is densest right at the wall
const SCREE_EMBED_DEPTH := 0.012 ## small -- these stones are only 4-23 cm tall, so BOULDER_EMBED_DEPTH (0.05) would bury the smallest ones
const SCREE_MAX_SLOPE_NORMAL_Y := 0.62 ## scree lodges on the talus slope itself, so it tolerates steeper ground than boulders (0.85)
const SCREE_KEEPOUT_RADIUS := 0.12 ## tiny footprint -- scree packs tightly and may sit right against (but not inside) cliff/outcrop footprints
const SCREE_MAX_PLACEMENT_ATTEMPTS := 3
const SCREE_FOOT_MARGIN_STEP_BACK := 1.2 ## extra distance per retry when a spot is too steep / blocked

## A real talus/scree cone is thickest right at the base of the cliff and
## thins out fast with distance -- a concave-upward accumulation profile,
## not a uniform band. BOULDER_FOOT_MARGIN_MIN/MAX still bound how close and
## how far a talus boulder can land; this exponent biases the random roll
## inside that band toward the near (MIN) end. pow(u, exponent) with
## exponent > 1 pushes a uniform [0,1] roll down toward 0, so most boulders
## cluster near the face and only a thinning few reach the far edge of the
## band -- see _scatter_boulders.
const BOULDER_TALUS_DENSITY_EXPONENT := 2.2

## 2026-09-20 (terrain-field-notes.html review, items 1-3):
## 1. Keep-outs -- talus/erratics no longer land inside cliff-dressing meshes (their real scanned
##    footprint from the top profiles, since these GLBs aren't centred on their origin) or on
##    top of flat rock outcrops. A blocked talus spot retries one step farther from the face.
const BOULDER_KEEPOUT_MARGIN := 0.5 ## extra world-unit gap around cliff footprints / outcrops
const BOULDER_KEEPOUT_RADIUS := 0.9 ## rough footprint radius of a scale-1.0 rock, multiplied by the rock's own scale
## 2. Clumps with gaps ("nothing is placed alone") -- each fault gets a few rockfall centres,
##    biased to sit under the cliff meshes actually on that fault (the visible debris source),
##    and its boulders spread around those instead of uniformly along the whole line. Count also
##    scales with step height relative to this map's average step (taller face = more rockfall).
const BOULDER_CLUSTER_SPACING := 20.0 ## one extra rockfall centre per this many units of fault length
const BOULDER_MAX_CLUSTERS_PER_FEATURE := 3
const BOULDER_CLUSTER_SPREAD := 3.0 ## std-dev (world units, along the fault) of boulders around a centre
const BOULDER_CLUSTER_FACE_BIAS := 0.75 ## chance a centre is placed under a cliff mesh on this fault (when there is one)
const BOULDER_FACE_MATCH_DIST := 8.0 ## max perpendicular distance for a cliff mesh to count as "on" a fault
const BOULDER_STEP_FACTOR_MIN := 0.6
const BOULDER_STEP_FACTOR_MAX := 1.5
## 3. Size sorting -- on real talus the biggest blocks roll farthest. Each boulder's size is
##    rolled first; this is how strongly that size pulls it toward the far end of the talus band
##    (0 = size and distance independent, as before; 1 = distance fully set by size).
const BOULDER_SIZE_SORTING := 0.6
const ERRATIC_COUNT_MIN_BASE := 15 ## count at ERRATIC_DENSITY_BASE_AREA
const ERRATIC_COUNT_MAX_BASE := 30 ## count at ERRATIC_DENSITY_BASE_AREA
const ERRATIC_SCALE_MIN := 0.9
const ERRATIC_SCALE_MAX := 2.2
const ERRATIC_MAX_SLOPE_NORMAL_Y := 0.92 ## stricter than BOULDER_MAX_SLOPE_NORMAL_Y -- erratics sit on genuinely flat floor, not a cliff-foot runout
const ERRATIC_MAX_PLACEMENT_ATTEMPTS := 6
const ERRATIC_REACH := 3.0 ## rough footprint radius used only to keep candidates off the very map edge (see _clamp_range_for_reach) -- erratics don't overlap-check against cliff features or each other, since real-world erratics are scattered independently of one another

## -- Knot talus + scree (2026-09-30) --
## Knot cliffs (knots.gd) are rows of cliff meshes, not cliff_features fault lines, so the talus and
## scree passes above never reached them -- their meshes only acted as keep-outs. Both passes now
## also scatter in front of every knot row's foot (row centre/facing/front edge read back from the
## knot meshes in cliff_plan), with the same size/distance rules as fault-line talus, plus:
##   - nothing lands on a knot level top (plateaus/ledges stay clear -- debris sits on low ground);
##   - boulders stay KNOT_TALUS_RAMP_CLEAR off every fallback ramp's centre line;
##   - a knot's boulders are kept only if every level its walk check reached is still reached with
##     them as rock (TerrainKnots.flood_reached_levels); otherwise they're re-added one by one and
##     any boulder that cuts a level off is dropped.
## Runs after the fault-line passes on the same RNG streams, so those placements are unchanged.
const KNOT_TALUS_MAX_PER_ROW := 5 ## boulders per knot row (count otherwise follows BOULDER_PER_FEATURE_LENGTH_DIVISOR)
const KNOT_TALUS_ROW_INSET := 0.1 ## fraction of a row's half-length kept clear at each end -- row ends are where paths go round
const KNOT_TALUS_RAMP_CLEAR := 4.5 ## metres from a ramp centre line kept free of boulders (bed half-width 2.5 + margin)
const KNOT_TALUS_BLOCK_PAD := 0.5 ## extra radius a boulder blocks in the walk check (~player capsule)

## Footprints (px, pz, radius -- pixel space) of every boulder/erratic placed by
## _scatter_boulders this run. _scatter_trees adds these to its keep-outs so tree
## trunks never grow through a rock. Rebuilt every run.
static var rock_keep_circles: Array[Vector3] = []

## The two scree materials (the boulders' are <dir>/<dir>_material.tres next to each glb).
## Read by tools/assign_flat_textures.gd diag_rock_averages().
const SCREE_MATERIAL_PATHS: Array[String] = [
	"res://assets/models/scree/namaqualand_rocks_01_material.tres",
	"res://assets/models/scree/namaqualand_stones_01_material.tres",
]

static func scatter_boulders(parent_node: Node, terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, cliff_features: Array[Dictionary], import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary], knots: Array) -> void:
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	# Clear any previous run's instances first -- this script regenerates
	# the live Terrain3D every time it runs (see _ready), so without this,
	# re-running would just keep piling more boulders on top of the old set.
	# Clears every rock mesh id in the pool, not just Boulder01's -- see
	# ROCK_MESH_IDS.
	for mesh_id in ROCK_MESH_IDS:
		instancer.clear_by_mesh(mesh_id)
	rock_keep_circles.clear()

	# Runtime collider container: a plain Node3D under the same parent as
	# this generator/Terrain3D, holding one StaticBody3D+CollisionShape3D
	# per boulder, built directly in the live tree -- no JSON side channel
	# and no separate editor-process script needed anymore.
	var parent := parent_node
	var old_container := parent.get_node_or_null(BOULDER_COLLIDER_CONTAINER_NAME)
	if old_container:
		old_container.queue_free()
	var collider_container := Node3D.new()
	collider_container.name = BOULDER_COLLIDER_CONTAINER_NAME
	# Deferred: this script's own _ready() runs while the scene tree is
	# still propagating NOTIFICATION_READY to Main's other children (the
	# "Parent node is busy setting up children" failure otherwise), so the
	# container is built off-tree (all its boulder children added below)
	# and only attached to Main once that initial setup finishes.
	parent.add_child.call_deferred(collider_container)

	# One convex collision shape per mesh id in the pool -- each rock is a
	# different mesh, so (unlike the old single-Boulder01 version) a single
	# shared shape no longer applies to every scattered instance.
	var rock_shapes: Dictionary = {}
	var hull_start_ms := Time.get_ticks_msec()
	for mesh_id in ROCK_MESH_IDS:
		var scene: PackedScene = load(ROCK_SCENE_PATHS[mesh_id])
		if scene:
			var sample := scene.instantiate()
			# 2026-09-30: hull from the LOWEST-poly LOD (last *_LODn), not LOD0. Every LOD
			# shares the same silhouette (dims within ~0.3%), and the simplified hull ends
			# up ~32 points either way -- but the batch-2 boulders' 59k-109k-tri LOD0s
			# took ~3.1 s to hull at startup.
			var lods := sample.find_children("*LOD*", "MeshInstance3D", true, false)
			lods.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
			var hull_src: MeshInstance3D = lods.back() if not lods.is_empty() else null
			if hull_src and hull_src.mesh:
				# simplify=true: the 2k meshes would otherwise give 300-500-point hulls; the
				# simplified hull is ~32 points and matches the rock's size within ~1-3%.
				rock_shapes[mesh_id] = hull_src.mesh.create_convex_shape(true, true)
			sample.free()
		if not rock_shapes.has(mesh_id):
			push_warning("TERRAIN_GEN: could not build a collision shape from %s (mesh id %d) -- these rocks will render but have no collision" % [ROCK_SCENE_PATHS[mesh_id], mesh_id])
	print("TERRAIN_GEN_STARTUP:   rock glb load + convex hulls (%d mesh ids): %.2fs" % [ROCK_MESH_IDS.size(), (Time.get_ticks_msec() - hull_start_ms) / 1000.0])

	# Per-mesh-id batches -- Terrain3DInstancer.add_transforms takes one mesh
	# id per call, so instances using different rock meshes can't share one
	# transforms array the way the old single-mesh version did.
	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for mesh_id in ROCK_MESH_IDS:
		transforms_by_mesh[mesh_id] = [] as Array[Transform3D]
		colors_by_mesh[mesh_id] = PackedColorArray()
	var collider_count := 0
	var talus_total := 0
	var erratic_total := 0

	# Item 1: keep-out zones. Cliff meshes as rotated boxes in each model's own scanned local
	# bounds (top profiles' x/z min/max, scaled) -- same local axes _build_cliff_dressing_
	# obstacle_mask uses for face_angle. Outcrops as circles (their bounding radius).
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
	var keepout_rejects := 0
	var cluster_total := 0
	var face_cluster_total := 0

	# Item 2: this map's average step height, so a fault's boulder count scales with how tall
	# its face is RELATIVE to the others (self-calibrating -- no absolute height constant).
	var step_sum := 0.0
	var step_n := 0
	for f in cliff_features:
		if f.has("step_height"):
			step_sum += absf(float(f.step_height))
			step_n += 1
	var mean_step := step_sum / float(step_n) if step_n > 0 else 1.0

	for feature in cliff_features:
		# Only the single-sided-step archetypes (ESCARPMENT/TERRACE/GENTLE_RISE)
		# get cliff-foot talus here -- V_RAVINE (symmetric, two walls, no one
		# "low side") and KNOLL (radial, not a fault line at all) don't fit
		# this foot-of-the-face placement at all. Proper talus for those (plus
		# the concave-upward accumulation profile and independent floor-
		# scattered glacial erratics) is a separate, dedicated rework -- see
		# the task list -- not a gap introduced here.
		if not feature.has("step_height"):
			continue
		var half_len: float = feature.half_len
		var axis_x: float = feature.axis_x
		var axis_z: float = feature.axis_z
		var perp_x: float = feature.perp_x
		var perp_z: float = feature.perp_z
		var step_height: float = feature.step_height
		var center: Vector2 = feature.center
		var curve_amplitude: float = feature.curve_amplitude
		var curve_frequency: float = feature.curve_frequency
		var curve_phase: float = feature.curve_phase
		var curve_frequency2: float = feature.curve_frequency2
		var curve_phase2: float = feature.curve_phase2
		var curve_weight2: float = feature.curve_weight2
		var edge_softness: float = feature.edge_softness

		# The face's "low" side is whichever side of d=0 does NOT get the
		# step_height boost added in _add_cliff_features -- see that
		# function's `face`/`local_height` comment. Boulders belong at the
		# foot of the drop, i.e. just past the face on that low side.
		var low_side_sign := -1.0 if step_height > 0.0 else 1.0

		var length_units := half_len * 2.0
		# Item 2: count scales with this face's height relative to the map's average step.
		var step_factor := clampf(absf(step_height) / maxf(mean_step, 0.001), BOULDER_STEP_FACTOR_MIN, BOULDER_STEP_FACTOR_MAX)
		var count_cap := maxi(BOULDER_MIN_PER_FEATURE, int(round(BOULDER_MAX_PER_FEATURE * step_factor)))
		var count := clampi(BOULDER_MIN_PER_FEATURE + int(length_units / BOULDER_PER_FEATURE_LENGTH_DIVISOR * step_factor), BOULDER_MIN_PER_FEATURE, count_cap)
		var usable_half_len := half_len * (1.0 - TerrainConfig.BOULDER_END_INSET_FRACTION)

		# Item 2: rockfall centres along this fault, biased under the cliff meshes sitting on it.
		var axis_v := Vector2(axis_x, axis_z)
		var perp_v := Vector2(perp_x, perp_z)
		var face_ts: Array[float] = []
		for kr in keep_rects:
			var rel: Vector2 = kr.c - center
			var t_e := rel.dot(axis_v)
			if absf(t_e) <= half_len and absf(rel.dot(perp_v)) <= BOULDER_FACE_MATCH_DIST:
				face_ts.append(t_e)
		var cluster_count := clampi(1 + int(length_units / BOULDER_CLUSTER_SPACING), 1, BOULDER_MAX_CLUSTERS_PER_FEATURE)
		var cluster_ts: Array[float] = []
		for c in cluster_count:
			var t0 := 0.0
			if not face_ts.is_empty() and rng.randf() < BOULDER_CLUSTER_FACE_BIAS:
				t0 = face_ts[rng.randi() % face_ts.size()] + rng.randf_range(-BOULDER_CLUSTER_SPREAD, BOULDER_CLUSTER_SPREAD)
				face_cluster_total += 1
			else:
				t0 = rng.randf_range(-usable_half_len, usable_half_len)
			cluster_ts.append(clampf(t0, -usable_half_len, usable_half_len))
		cluster_total += cluster_count

		for i in count:
			var t := clampf(rng.randfn(cluster_ts[rng.randi() % cluster_ts.size()], BOULDER_CLUSTER_SPREAD), -usable_half_len, usable_half_len)
			# Item 3: size first -- it steers both this boulder's scale and how far out it lands.
			var size_u := rng.randf()
			var size_scale := lerpf(BOULDER_SCALE_MIN, BOULDER_SCALE_MAX, size_u)
			# Same curve_offset formula _add_cliff_features itself uses to bend
			# the fault line -- without this, a fixed straight-line `d` offset
			# can still land ON the (curved) face instead of past it, which is
			# what was placing boulders half-buried into the cliff.
			var normalized_t := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve_offset := curve_amplitude * lerpf(sin(normalized_t * PI * curve_frequency + curve_phase), sin(normalized_t * PI * curve_frequency2 + curve_phase2), curve_weight2)
			var lateral_jitter := rng.randf_range(-BOULDER_LATERAL_JITTER, BOULDER_LATERAL_JITTER)

			# Retry farther from the face if the sampled spot is still steep, OR
			# still inside the road's graded corridor (road_weight > 0 -- see
			# _generate_road) -- guards against curve wobble near the tips,
			# ordinary rolling terrain slope near the foot, AND a cliff foot that
			# happens to sit where the road grading flattened/regraded it, rather
			# than trusting a single fixed offset to always land on flat,
			# road-free ground. Candidate XZ is clamped into the actual generated
			# heightmap bounds ([0,width-1]x[0,length-1]) BEFORE sampling --
			# without this, a foot offset that pushes past the map edge (more
			# likely now that features get placed close to the wall/rim, near
			# the edge) would sample _sample_height_bilinear's internal edge
			# clamp for height while the boulder's WORLD position still sits
			# beyond the actual terrain region -- exactly what was placing
			# boulders floating in empty space past the generated ground.
			var px := 0.0
			var pz := 0.0
			var height := 0.0
			var normal := Vector3.UP
			var found_clear_spot := false
			for attempt in BOULDER_MAX_PLACEMENT_ATTEMPTS:
				# Concave-upward talus accumulation: bias the roll toward the near
				# (MIN) end of the band so boulders pile up close to the face and
				# thin out with distance, instead of scattering evenly across the
				# whole band -- see BOULDER_TALUS_DENSITY_EXPONENT.
				# Item 3: bigger rocks pulled toward the far end of the band (fall sorting).
				var talus_t := lerpf(pow(rng.randf(), BOULDER_TALUS_DENSITY_EXPONENT), size_u, BOULDER_SIZE_SORTING)
				var margin := edge_softness + BOULDER_FOOT_MARGIN_MIN + attempt * BOULDER_FOOT_MARGIN_STEP_BACK \
					+ talus_t * (BOULDER_FOOT_MARGIN_MAX - BOULDER_FOOT_MARGIN_MIN)
				var d := low_side_sign * margin + curve_offset + lateral_jitter
				px = clampf(center.x + t * axis_x + d * perp_x, 0.0, float(width - 1))
				pz = clampf(center.y + t * axis_z + d * perp_z, 0.0, float(length - 1))
				height = TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
				normal = TerrainUtil.sample_normal(heights, width, length, px, pz)
				var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
				var on_road := road_weight[sample_idx] > 0.0
				if normal.y >= BOULDER_MAX_SLOPE_NORMAL_Y and not on_road:
					if boulder_blocked(px, pz, BOULDER_KEEPOUT_RADIUS * size_scale, keep_rects, keep_circles):
						keepout_rejects += 1 # item 1: inside a cliff mesh / outcrop -- retry farther out
					else:
						found_clear_spot = true
						break
				# else: loop retries one step farther out.

			if not found_clear_spot:
				# Never found a spot that's both flat enough and clear of the
				# road within BOULDER_MAX_PLACEMENT_ATTEMPTS -- skip this one
				# boulder rather than force it onto the road or a steep face.
				continue

			var boulder_pos := Vector3(import_position.x + px, height - BOULDER_EMBED_DEPTH, import_position.z + pz)
			var align := Quaternion(Vector3.UP, normal)
			var spin := Quaternion(normal, rng.randf_range(0.0, TAU))
			var mesh_id: int = ROCK_MESH_IDS[rng.randi() % ROCK_MESH_IDS.size()]
			var boulder_scale: float = size_scale * float(ROCK_BASE_SCALE[mesh_id]) # item 3: size rolled up front
			var boulder_basis := Basis(spin * align).scaled(Vector3.ONE * boulder_scale)

			transforms_by_mesh[mesh_id].append(Transform3D(boulder_basis, boulder_pos))
			rock_keep_circles.append(Vector3(px, pz, BOULDER_KEEPOUT_RADIUS * boulder_scale))
			colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
			talus_total += 1

			var shape: Shape3D = rock_shapes.get(mesh_id)
			if shape:
				_add_rock_collider(collider_container, shape, Transform3D(boulder_basis, boulder_pos), collider_count)
				collider_count += 1

	var talus_count := talus_total

	# Independent glacial-erratic scatter -- unrelated to any cliff feature
	# (see ERRATIC_* consts above). Candidates are drawn straight from the
	# valley floor zone, reusing _zone_pixel_range/_clamp_range_for_reach the
	# same way feature placement keeps footprints off the map edge, then
	# rejected/retried if too steep or on the road -- same idea as the talus
	# loop above, but with its own looser attempt budget, stricter flatness
	# requirement, and bigger scale range (a lone erratic reads as one
	# dramatic dropped boulder, not a pile of cliff debris).
	# Scale the base 256x256-calibrated count range by actual map area so
	# erratic density (not just a flat headcount) stays constant as
	# AREA_WIDTH/AREA_LENGTH change -- same reasoning as FEATURE_DENSITY.
	var erratic_area_scale := (float(width) * float(length)) / TerrainConfig.ERRATIC_DENSITY_BASE_AREA
	var erratic_count_min := maxi(1, int(round(ERRATIC_COUNT_MIN_BASE * erratic_area_scale)))
	var erratic_count_max := maxi(erratic_count_min, int(round(ERRATIC_COUNT_MAX_BASE * erratic_area_scale)))
	var erratic_roll_count := rng.randi_range(erratic_count_min, erratic_count_max)
	var floor_x_range := TerrainUtil.zone_pixel_range("floor", width, rng)
	var floor_x := TerrainUtil.clamp_range_for_reach(floor_x_range.x, floor_x_range.y, ERRATIC_REACH, float(width - 1))
	var floor_z := TerrainUtil.clamp_range_for_reach(float(length) * 0.05, float(length) * 0.95, ERRATIC_REACH, float(length - 1))

	for i in erratic_roll_count:
		var found_clear_spot := false
		var px := 0.0
		var pz := 0.0
		var height := 0.0
		var normal := Vector3.UP
		for attempt in ERRATIC_MAX_PLACEMENT_ATTEMPTS:
			px = rng.randf_range(minf(floor_x.x, floor_x.y), maxf(floor_x.x, floor_x.y))
			pz = rng.randf_range(minf(floor_z.x, floor_z.y), maxf(floor_z.x, floor_z.y))
			height = TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
			normal = TerrainUtil.sample_normal(heights, width, length, px, pz)
			var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
			var on_road := road_weight[sample_idx] > 0.0
			if normal.y >= ERRATIC_MAX_SLOPE_NORMAL_Y and not on_road:
				# item 1: erratic scale isn't rolled yet -- check against the largest it can be
				if boulder_blocked(px, pz, BOULDER_KEEPOUT_RADIUS * ERRATIC_SCALE_MAX, keep_rects, keep_circles):
					keepout_rejects += 1
				else:
					found_clear_spot = true
					break

		if not found_clear_spot:
			continue

		var erratic_pos := Vector3(import_position.x + px, height - BOULDER_EMBED_DEPTH, import_position.z + pz)
		var erratic_align := Quaternion(Vector3.UP, normal)
		var erratic_spin := Quaternion(normal, rng.randf_range(0.0, TAU))
		var mesh_id: int = ROCK_MESH_IDS[rng.randi() % ROCK_MESH_IDS.size()]
		var erratic_scale: float = rng.randf_range(ERRATIC_SCALE_MIN, ERRATIC_SCALE_MAX) * float(ROCK_BASE_SCALE[mesh_id])
		var erratic_basis := Basis(erratic_spin * erratic_align).scaled(Vector3.ONE * erratic_scale)

		transforms_by_mesh[mesh_id].append(Transform3D(erratic_basis, erratic_pos))
		rock_keep_circles.append(Vector3(px, pz, BOULDER_KEEPOUT_RADIUS * erratic_scale))
		colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
		erratic_total += 1

		var shape: Shape3D = rock_shapes.get(mesh_id)
		if shape:
			_add_rock_collider(collider_container, shape, Transform3D(erratic_basis, erratic_pos), collider_count)
			collider_count += 1

	var erratic_count := erratic_total

	# Knot talus (2026-09-30) -- see the KNOT_TALUS_* block above. Per knot: candidates in front of
	# each row's foot, then the knot's walk check with the boulders as rock.
	var knot_talus_total := 0
	var knot_talus_dropped := 0
	var knot_talus_parts: Array[String] = [] # per knot: "#i N (L lvl)" for the debug line
	var knot_rows := _knot_rows(cliff_plan, cliff_top_profiles)
	for knot in knots:
		var ki := int(knot.index)
		var rock := TerrainKnots.knot_rock_mask(ki, cliff_plan, width, length)
		var tops := TerrainKnots.level_top_mask(knot, heights, width, length, rock)
		var placed: Array[Dictionary] = []
		for row in knot_rows:
			if int(row.knot) != ki:
				continue
			var row_half: float = row.half_len
			var usable := row_half * (1.0 - KNOT_TALUS_ROW_INSET)
			var count := clampi(BOULDER_MIN_PER_FEATURE + int(row_half * 2.0 / BOULDER_PER_FEATURE_LENGTH_DIVISOR), BOULDER_MIN_PER_FEATURE, KNOT_TALUS_MAX_PER_ROW)
			var t_centre := rng.randf_range(-usable, usable) # one rockfall centre per row
			for i in count:
				var size_u := rng.randf()
				var size_scale := lerpf(BOULDER_SCALE_MIN, BOULDER_SCALE_MAX, size_u)
				var radius := BOULDER_KEEPOUT_RADIUS * size_scale
				var t := clampf(rng.randfn(t_centre, BOULDER_CLUSTER_SPREAD), -usable, usable)
				var px := 0.0
				var pz := 0.0
				var found_clear_spot := false
				for attempt in BOULDER_MAX_PLACEMENT_ATTEMPTS:
					var talus_t := lerpf(pow(rng.randf(), BOULDER_TALUS_DENSITY_EXPONENT), size_u, BOULDER_SIZE_SORTING)
					var dist := float(row.front) + BOULDER_FOOT_MARGIN_MIN + attempt * BOULDER_FOOT_MARGIN_STEP_BACK \
						+ talus_t * (BOULDER_FOOT_MARGIN_MAX - BOULDER_FOOT_MARGIN_MIN)
					var p: Vector2 = row.center + row.along * t + row.face * dist
					px = clampf(p.x, 0.0, float(width - 1))
					pz = clampf(p.y, 0.0, float(length - 1))
					var normal := TerrainUtil.sample_normal(heights, width, length, px, pz)
					var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
					if normal.y < BOULDER_MAX_SLOPE_NORMAL_Y or road_weight[sample_idx] > 0.0:
						continue
					if boulder_blocked(px, pz, radius, keep_rects, keep_circles):
						keepout_rejects += 1
						continue
					if _mask_hits_circle(tops, px, pz, radius, width, length) or _near_knot_ramp(knot, px, pz, KNOT_TALUS_RAMP_CLEAR + radius):
						continue
					found_clear_spot = true
					break
				if found_clear_spot:
					placed.append({"px": px, "pz": pz, "size": size_scale})

		# Walk check: every level reached without the boulders must still be reached with them.
		var baseline := TerrainKnots.flood_reached_levels(knot, heights, width, length, rock)
		if not placed.is_empty() and not baseline.is_empty():
			var block := rock.duplicate()
			for b in placed:
				_stamp_circle(block, b.px, b.pz, BOULDER_KEEPOUT_RADIUS * float(b.size) + KNOT_TALUS_BLOCK_PAD, width, length)
			if _lost_any(baseline, TerrainKnots.flood_reached_levels(knot, heights, width, length, block)):
				# Something got cut off: re-add one at a time, dropping each boulder that causes it.
				block = rock.duplicate()
				var kept: Array[Dictionary] = []
				for b in placed:
					var test := block.duplicate()
					_stamp_circle(test, b.px, b.pz, BOULDER_KEEPOUT_RADIUS * float(b.size) + KNOT_TALUS_BLOCK_PAD, width, length)
					if _lost_any(baseline, TerrainKnots.flood_reached_levels(knot, heights, width, length, test)):
						knot_talus_dropped += 1
					else:
						block = test
						kept.append(b)
				placed = kept
		knot_talus_parts.append("#%d %d (%d lvl)" % [ki, placed.size(), baseline.size()])

		for b in placed:
			var bpx: float = b.px
			var bpz: float = b.pz
			var normal := TerrainUtil.sample_normal(heights, width, length, bpx, bpz)
			var pos := Vector3(import_position.x + bpx, TerrainUtil.sample_height_bilinear(heights, width, length, bpx, bpz) - BOULDER_EMBED_DEPTH, import_position.z + bpz)
			var mesh_id: int = ROCK_MESH_IDS[rng.randi() % ROCK_MESH_IDS.size()]
			var knot_scale: float = float(b.size) * float(ROCK_BASE_SCALE[mesh_id])
			var knot_basis := Basis(Quaternion(normal, rng.randf_range(0.0, TAU)) * Quaternion(Vector3.UP, normal)).scaled(Vector3.ONE * knot_scale)
			transforms_by_mesh[mesh_id].append(Transform3D(knot_basis, pos))
			colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
			rock_keep_circles.append(Vector3(bpx, bpz, BOULDER_KEEPOUT_RADIUS * knot_scale))
			knot_talus_total += 1
			var shape: Shape3D = rock_shapes.get(mesh_id)
			if shape:
				_add_rock_collider(collider_container, shape, Transform3D(knot_basis, pos), collider_count)
				collider_count += 1

	var total_count := talus_count + erratic_count + knot_talus_total

	if total_count == 0:
		print("TERRAIN_GEN: no boulders scattered (no cliff features placed, no erratics found a clear spot)")
		return

	for mesh_id in ROCK_MESH_IDS:
		if not transforms_by_mesh[mesh_id].is_empty():
			instancer.add_transforms(mesh_id, transforms_by_mesh[mesh_id], colors_by_mesh[mesh_id], true)

	print("TERRAIN_GEN: scattered %d talus boulder(s) + %d glacial erratic(s) + %d knot talus = %d total (%d with collision) along %d cliff feature(s) + %d knot(s)" % [talus_count, erratic_count, knot_talus_total, total_count, collider_count, cliff_features.size(), knots.size()])
	print("TERRAIN_GEN_DEBUG knot talus -- per knot (boulders, levels walk-checked): %s; %d boulder(s) dropped by the walk check" % [", ".join(knot_talus_parts), knot_talus_dropped])
	print("TERRAIN_GEN_DEBUG boulders -- %d rockfall centre(s) (%d under a cliff mesh), %d spot(s) rejected by cliff/outcrop keep-outs, mean step %.2f" % [cluster_total, face_cluster_total, keepout_rejects, mean_step])

## Scree layer -- a dense, collider-free debris carpet at each cliff foot,
## layered under the boulders. Deliberately mirrors _scatter_boulders' talus
## loop (same cliff_features fault data, same keep-out rects/circles, same
## road_weight + slope-normal rejection, same ground-aligned + random-yaw
## basis and height-embed) so scree lands exactly where the boulders' talus
## does -- only far denser, in a tighter near-face band, tolerating steeper
## ground, drawn from the fist/gravel scree pools, and with NO StaticBody
## colliders built (scree is cosmetic; the terrain collider carries the
## ground). Same timing contract as _scatter_boulders: after import_images(),
## before save_directory().
static func scatter_scree(terrain: Terrain3D, heights: PackedFloat32Array, width: int, length: int, cliff_features: Array[Dictionary], import_position: Vector3, rng: RandomNumberGenerator, road_weight: PackedFloat32Array, cliff_plan: Array[Dictionary], cliff_top_profiles: Dictionary, outcrop_plan: Array[Dictionary], knots: Array) -> void:
	var instancer: Terrain3DInstancer = terrain.get_instancer()
	for mesh_id in SCREE_MESH_IDS:
		instancer.clear_by_mesh(mesh_id)

	# Keep-outs: identical construction to _scatter_boulders (cliff meshes as
	# rotated boxes in their own scanned local bounds, outcrops as circles).
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

	# Same self-calibrating mean step height as the boulder pass.
	var step_sum := 0.0
	var step_n := 0
	for f in cliff_features:
		if f.has("step_height"):
			step_sum += absf(float(f.step_height))
			step_n += 1
	var mean_step := step_sum / float(step_n) if step_n > 0 else 1.0

	var transforms_by_mesh: Dictionary = {}
	var colors_by_mesh: Dictionary = {}
	for mesh_id in SCREE_MESH_IDS:
		transforms_by_mesh[mesh_id] = [] as Array[Transform3D]
		colors_by_mesh[mesh_id] = PackedColorArray()
	var scree_total := 0

	for feature in cliff_features:
		# Same archetype subset as _scatter_boulders (single-sided step faces only).
		if not feature.has("step_height"):
			continue
		var half_len: float = feature.half_len
		var axis_x: float = feature.axis_x
		var axis_z: float = feature.axis_z
		var perp_x: float = feature.perp_x
		var perp_z: float = feature.perp_z
		var step_height: float = feature.step_height
		var center: Vector2 = feature.center
		var curve_amplitude: float = feature.curve_amplitude
		var curve_frequency: float = feature.curve_frequency
		var curve_phase: float = feature.curve_phase
		var curve_frequency2: float = feature.curve_frequency2
		var curve_phase2: float = feature.curve_phase2
		var curve_weight2: float = feature.curve_weight2
		var edge_softness: float = feature.edge_softness

		var low_side_sign := -1.0 if step_height > 0.0 else 1.0
		var length_units := half_len * 2.0
		var step_factor := clampf(absf(step_height) / maxf(mean_step, 0.001), BOULDER_STEP_FACTOR_MIN, BOULDER_STEP_FACTOR_MAX)
		var count_cap := maxi(SCREE_MIN_PER_FEATURE, int(round(SCREE_MAX_PER_FEATURE * step_factor)))
		var count := clampi(SCREE_MIN_PER_FEATURE + int(length_units / SCREE_PER_FEATURE_LENGTH_DIVISOR * step_factor), SCREE_MIN_PER_FEATURE, count_cap)
		var usable_half_len := half_len * (1.0 - SCREE_END_INSET_FRACTION)

		for i in count:
			var t := rng.randf_range(-usable_half_len, usable_half_len)
			var size_u := rng.randf()
			var size_scale := lerpf(SCREE_SCALE_MIN, SCREE_SCALE_MAX, size_u)
			var normalized_t := clampf(t / half_len, -1.0, 1.0) if half_len > 0.0001 else 0.0
			var curve_offset := curve_amplitude * lerpf(sin(normalized_t * PI * curve_frequency + curve_phase), sin(normalized_t * PI * curve_frequency2 + curve_phase2), curve_weight2)
			var lateral_jitter := rng.randf_range(-SCREE_LATERAL_JITTER, SCREE_LATERAL_JITTER)

			var px := 0.0
			var pz := 0.0
			var height := 0.0
			var normal := Vector3.UP
			var found_clear_spot := false
			for attempt in SCREE_MAX_PLACEMENT_ATTEMPTS:
				# Concave-upward pile-up, even stronger than the boulder talus.
				var talus_t := pow(rng.randf(), SCREE_TALUS_DENSITY_EXPONENT)
				var margin := edge_softness + SCREE_FOOT_MARGIN_MIN + attempt * SCREE_FOOT_MARGIN_STEP_BACK \
					+ talus_t * (SCREE_FOOT_MARGIN_MAX - SCREE_FOOT_MARGIN_MIN)
				var d := low_side_sign * margin + curve_offset + lateral_jitter
				px = clampf(center.x + t * axis_x + d * perp_x, 0.0, float(width - 1))
				pz = clampf(center.y + t * axis_z + d * perp_z, 0.0, float(length - 1))
				height = TerrainUtil.sample_height_bilinear(heights, width, length, px, pz)
				normal = TerrainUtil.sample_normal(heights, width, length, px, pz)
				var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
				var on_road := road_weight[sample_idx] > 0.0
				if normal.y >= SCREE_MAX_SLOPE_NORMAL_Y and not on_road:
					if not boulder_blocked(px, pz, SCREE_KEEPOUT_RADIUS * size_scale, keep_rects, keep_circles):
						found_clear_spot = true
						break
				# else: retry one step farther out.

			if not found_clear_spot:
				continue

			var pos := Vector3(import_position.x + px, height - SCREE_EMBED_DEPTH, import_position.z + pz)
			var align := Quaternion(Vector3.UP, normal)
			var spin := Quaternion(normal, rng.randf_range(0.0, TAU))
			# Weighted pool pick: mostly fine gravel, a scatter of larger chips.
			var mesh_id: int
			if rng.randf() < SCREE_GRAVEL_FRACTION:
				mesh_id = SCREE_GRAVEL_MESH_IDS[rng.randi() % SCREE_GRAVEL_MESH_IDS.size()]
			else:
				mesh_id = SCREE_FIST_MESH_IDS[rng.randi() % SCREE_FIST_MESH_IDS.size()]
			var basis := Basis(spin * align).scaled(Vector3.ONE * size_scale)
			transforms_by_mesh[mesh_id].append(Transform3D(basis, pos))
			colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
			scree_total += 1

	# Knot scree (2026-09-30) -- same foot band as the knot talus in scatter_boulders, scree's own
	# density/band/slope rules. No colliders, so no ramp or walk check; level tops still stay clear.
	var knot_scree_total := 0
	var knot_rows := _knot_rows(cliff_plan, cliff_top_profiles)
	for knot in knots:
		var ki := int(knot.index)
		var tops := TerrainKnots.level_top_mask(knot, heights, width, length, TerrainKnots.knot_rock_mask(ki, cliff_plan, width, length))
		for row in knot_rows:
			if int(row.knot) != ki:
				continue
			var row_half: float = row.half_len
			var usable := row_half * (1.0 - SCREE_END_INSET_FRACTION)
			var count := clampi(SCREE_MIN_PER_FEATURE + int(row_half * 2.0 / SCREE_PER_FEATURE_LENGTH_DIVISOR), SCREE_MIN_PER_FEATURE, SCREE_MAX_PER_FEATURE)
			for i in count:
				var t := rng.randf_range(-usable, usable)
				var size_scale := lerpf(SCREE_SCALE_MIN, SCREE_SCALE_MAX, rng.randf())
				var px := 0.0
				var pz := 0.0
				var normal := Vector3.UP
				var found_clear_spot := false
				for attempt in SCREE_MAX_PLACEMENT_ATTEMPTS:
					var dist := float(row.front) + SCREE_FOOT_MARGIN_MIN + attempt * SCREE_FOOT_MARGIN_STEP_BACK \
						+ pow(rng.randf(), SCREE_TALUS_DENSITY_EXPONENT) * (SCREE_FOOT_MARGIN_MAX - SCREE_FOOT_MARGIN_MIN)
					var p: Vector2 = row.center + row.along * (t + rng.randf_range(-SCREE_LATERAL_JITTER, SCREE_LATERAL_JITTER)) + row.face * dist
					px = clampf(p.x, 0.0, float(width - 1))
					pz = clampf(p.y, 0.0, float(length - 1))
					normal = TerrainUtil.sample_normal(heights, width, length, px, pz)
					var sample_idx := clampi(int(round(pz)), 0, length - 1) * width + clampi(int(round(px)), 0, width - 1)
					if normal.y < SCREE_MAX_SLOPE_NORMAL_Y or road_weight[sample_idx] > 0.0 or tops[sample_idx] == 1:
						continue
					if boulder_blocked(px, pz, SCREE_KEEPOUT_RADIUS * size_scale, keep_rects, keep_circles):
						continue
					found_clear_spot = true
					break
				if not found_clear_spot:
					continue
				var pos := Vector3(import_position.x + px, TerrainUtil.sample_height_bilinear(heights, width, length, px, pz) - SCREE_EMBED_DEPTH, import_position.z + pz)
				var mesh_id: int
				if rng.randf() < SCREE_GRAVEL_FRACTION:
					mesh_id = SCREE_GRAVEL_MESH_IDS[rng.randi() % SCREE_GRAVEL_MESH_IDS.size()]
				else:
					mesh_id = SCREE_FIST_MESH_IDS[rng.randi() % SCREE_FIST_MESH_IDS.size()]
				var basis := Basis(Quaternion(normal, rng.randf_range(0.0, TAU)) * Quaternion(Vector3.UP, normal)).scaled(Vector3.ONE * size_scale)
				transforms_by_mesh[mesh_id].append(Transform3D(basis, pos))
				colors_by_mesh[mesh_id].append(Color(1.0, 1.0, 1.0, 1.0))
				knot_scree_total += 1

	for mesh_id in SCREE_MESH_IDS:
		if not transforms_by_mesh[mesh_id].is_empty():
			instancer.add_transforms(mesh_id, transforms_by_mesh[mesh_id], colors_by_mesh[mesh_id], true)

	print("TERRAIN_GEN: scattered %d scree stone(s) across %d cliff feature(s) + %d at %d knot(s)" % [scree_total + knot_scree_total, cliff_features.size(), knot_scree_total, knots.size()])

## Knot rows for the knot talus/scree passes: one {knot, center, face, along, half_len, front} per
## (knot, knot_row) group of knot meshes in cliff_plan, pixel space. face = mean mesh facing (the
## foot side), front = how far in front of `center` the rock reaches (scanned top profiles' z_max,
## the same local +z the keep-out rects use), so the foot band starts at the real face.
static func _knot_rows(cliff_plan: Array[Dictionary], top_profiles: Dictionary) -> Array[Dictionary]:
	var defs: Dictionary = {}
	for def in TerrainConfig.CLIFF_DRESSING_DEFS:
		defs[def.name] = def
	var groups: Dictionary = {}
	for e in cliff_plan:
		if not e.has("knot"):
			continue
		var key := "%d/%s" % [int(e.knot), String(e.knot_row)]
		if not groups.has(key):
			groups[key] = []
		groups[key].append(e)
	var rows: Array[Dictionary] = []
	for key in groups:
		var es: Array = groups[key]
		var c := Vector2.ZERO
		var f := Vector2.ZERO
		for e in es:
			c += Vector2(float(e.px), float(e.pz))
			f += Vector2(float(e.face_dir_x), float(e.face_dir_z))
		c /= float(es.size())
		f = f.normalized()
		var along := Vector2(-f.y, f.x)
		var half_len := 0.0
		var front := 0.0
		for e in es:
			var d = defs.get(e.def_name)
			if d == null:
				continue
			var sj: float = e.scale_jitter
			var rel := Vector2(float(e.px), float(e.pz)) - c
			var prof: Dictionary = top_profiles.get(e.def_name, {})
			half_len = maxf(half_len, absf(rel.dot(along)) + float(d.real_size) * sj * 0.5)
			front = maxf(front, rel.dot(f) + float(prof.get("z_max", float(d.depth) * 0.5)) * sj)
		rows.append({"knot": int(es[0].knot), "center": c, "face": f, "along": along, "half_len": half_len, "front": front})
	return rows

## True if any pixel within `radius` of (px, pz) is set in `mask`.
static func _mask_hits_circle(mask: PackedByteArray, px: float, pz: float, radius: float, width: int, length: int) -> bool:
	for z in range(clampi(int(floor(pz - radius)), 0, length - 1), clampi(int(ceil(pz + radius)), 0, length - 1) + 1):
		for x in range(clampi(int(floor(px - radius)), 0, width - 1), clampi(int(ceil(px + radius)), 0, width - 1) + 1):
			if mask[z * width + x] == 1 and Vector2(x, z).distance_to(Vector2(px, pz)) <= radius:
				return true
	return false

## Sets every pixel within `radius` of (px, pz) in `mask`.
static func _stamp_circle(mask: PackedByteArray, px: float, pz: float, radius: float, width: int, length: int) -> void:
	for z in range(clampi(int(floor(pz - radius)), 0, length - 1), clampi(int(ceil(pz + radius)), 0, length - 1) + 1):
		for x in range(clampi(int(floor(px - radius)), 0, width - 1), clampi(int(ceil(px + radius)), 0, width - 1) + 1):
			if Vector2(x, z).distance_to(Vector2(px, pz)) <= radius:
				mask[z * width + x] = 1

## True if (px, pz) is within `clear` of any of the knot's fallback ramp centre lines.
static func _near_knot_ramp(knot: Dictionary, px: float, pz: float, clear: float) -> bool:
	var p := Vector2(px, pz)
	for r in knot.get("ramp_paths", []):
		var a: Vector2 = r.from
		var b: Vector2 = r.to
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) < clear:
			return true
	return false

## True if some level `baseline` lists is missing from `now`.
static func _lost_any(baseline: Array[String], now: Array[String]) -> bool:
	for n in baseline:
		if not now.has(n):
			return true
	return false

## One StaticBody3D + CollisionShape3D for a scattered rock, under the collider container.
static func _add_rock_collider(container: Node3D, shape: Shape3D, xform: Transform3D, index: int) -> void:
	var body := StaticBody3D.new()
	body.name = "Boulder%d" % index
	container.add_child(body)
	body.transform = xform
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	col.shape = shape
	body.add_child(col)

## Item 1 keep-out test (pixel space): true if a rock of `radius` at (px, pz) overlaps a cliff
## mesh's rotated local footprint (+ BOULDER_KEEPOUT_MARGIN) or an outcrop's bounding circle.
static func boulder_blocked(px: float, pz: float, radius: float, keep_rects: Array[Dictionary], keep_circles: Array[Vector3]) -> bool:
	var p := Vector2(px, pz)
	var pad := radius + BOULDER_KEEPOUT_MARGIN
	for kr in keep_rects:
		var d: Vector2 = p - kr.c
		var lx := d.dot(kr.ax)
		var lz := d.dot(kr.az)
		if lx >= float(kr.x0) - pad and lx <= float(kr.x1) + pad and lz >= float(kr.z0) - pad and lz <= float(kr.z1) + pad:
			return true
	for kc in keep_circles:
		if p.distance_to(Vector2(kc.x, kc.y)) < kc.z + pad:
			return true
	return false

## Restores this module's static state (caches, debug buffers, counters) to its initial
## values. Called at the start of every WorldGenerator run so each run starts clean, the
## same as when these were per-instance member variables on WorldGenerator.
static func reset_run_state() -> void:
	rock_keep_circles = []
